i#!/usr/bin/env zsh
set -euo pipefail

# ---------------------------
# QTGMC batch wrapper (macOS)
# ---------------------------
# Modes:
#   dvd  <makemkv_disc_spec> <rip_dir> <export_dir>
#   file <input_file>        <export_dir>
#
# Thread controls (set via env, else defaults):
: "${VS_THREADS:=6}"           # VapourSynth threads (via vspipe --threads)
: "${FFMPEG_THREADS:=6}"       # FFmpeg encoder/IO threads (-threads)
: "${FILTER_THREADS:=4}"       # FFmpeg filter threads (-filter_threads)
#
# Audio options:
#   MONO_DUP=1   -> duplicate mono to stereo
#   FORCE_L_TO_R=1 -> duplicate left channel into both L/R for stereo sources
#
# Encoder controls:
: "${VT_BITRATE:=40M}"         # h264_videotoolbox target bitrate
: "${VT_MAXRATE:=50M}"
: "${VT_BUFSIZE:=80M}"
: "${X264_CRF:=16}"            # used if you flip to libx264 path

SCRIPT_DIR="${0:A:h}"
WORK_VPY=""   # temp .vpy path

cleanup() {
  [[ -n "${WORK_VPY:-}" && -f "$WORK_VPY" ]] && rm -f "$WORK_VPY"
}
trap cleanup EXIT

_abspath() { perl -MCwd=realpath -e 'print realpath(shift)' "$1"; }

err() { print -u2 -- "xx $*"; exit 1; }
note() { print -- "$*"; }

need() {
  for b in "$@"; do
    command -v "$b" >/dev/null 2>&1 || err "Missing dependency: $b"
  done
}

# Detect basic media props with ffprobe (json-safe)
probe_json() {
  local f="$1"
  ffprobe -hide_banner -v error -print_format json -show_streams -show_format -- "$f"
}

# Decide audio filter if we need duplication
pick_audio_filter() {
  local json="$1"
  local af=""
  # mono -> duplicate
  if echo "$json" | python3 - "$json" <<'PY'
import sys, json
d=json.load(sys.stdin)
for s in d.get("streams",[]):
    if s.get("codec_type")=="audio":
        ch=s.get("channels")
        if ch==1: print("mono"); break
PY
  then
    af='-af pan=stereo|c0=c0|c1=c0'
  fi

  # left-to-both override
  if [[ "${FORCE_L_TO_R:-0}" = "1" ]]; then
    af='-af pan=stereo|c0=FL|c1=FL'
  fi

  [[ "${MONO_DUP:-0}" = "1" && -z "$af" ]] && af='-af pan=stereo|c0=c0|c1=c0'
  print -r -- "$af"
}

# Write a temp .vpy from a template, replacing INPUT path
make_vpy() {
  local tmpl="$1"
  local src="$2"
  WORK_VPY="$(mktemp -t qtgmc_vpy.XXXXXX).vpy"
  sed "s|INPUT_FILE|$src|g; s|INPUT_DV\.avi|$src|g" -- "$tmpl" > "$WORK_VPY"
  print -r -- "$WORK_VPY"
}

# Ensure ffms2 plugin symlink exists as brew caveat states
ensure_ffms2_link() {
  local d="/opt/homebrew/lib/vapoursynth"
  [[ -e "$d/libffms2.dylib" ]] || {
    [[ -e "/opt/homebrew/lib/libffms2.dylib" ]] || err "libffms2.dylib not found; brew install ffms2"
    (cd "$d" && ln -sf "../libffms2.dylib" "libffms2.dylib")
  }
}

# Verify VS plugins we need are visible
check_vs_plugins() {
  python3 - <<'PY'
import vapoursynth as vs
c=vs.core
missing=[]
for name in ("ffms2","fmtc","misc","znedi3"):
    if not hasattr(c,name): missing.append(name)
if missing:
    raise SystemExit("Missing VS plugins: "+", ".join(missing))
PY
}

# Encode helper (Y4M from vspipe -> ffmpeg -> MP4)
encode_to_mp4() {
  local y4m_src="$1"    # '-' recommended
  local a_src="$2"      # original file for audio
  local out="$3"
  local aflags="${4:-}"

  ffmpeg -hide_banner \
    -f yuv4mpegpipe -i "$y4m_src" -i "$a_src" \
    -map 0:v:0 -map 1:a:0 \
    -vf "scale=3840:2160:flags=bicubic,format=yuv420p" \
    -c:v h264_videotoolbox -b:v "$VT_BITRATE" -maxrate "$VT_MAXRATE" -bufsize "$VT_BUFSIZE" \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
    -c:a aac -b:a 192k \
    -threads "$FFMPEG_THREADS" -filter_threads "$FILTER_THREADS" \
    $aflags \
    -movflags +faststart \
    -- "$out"
}

# ===== main flow =====
need vspipe ffmpeg ffprobe python3 sed mktemp

[[ $# -lt 1 ]] && err "Usage:
  ${0:t} dvd  disc:0            <rip_dir> <export_dir>
  ${0:t} file <input_file>      <export_dir>"

mode="$1"; shift

ensure_ffms2_link
check_vs_plugins

case "$mode" in
  dvd)
    [[ $# -eq 3 ]] || err "dvd mode: disc_spec rip_dir export_dir"
    disc="$1"; ripdir="$(_abspath "$2")"; outdir="$(_abspath "$3")"
    mkdir -p "$ripdir" "$outdir"
    note ">> Ripping all titles ≥20 min to $ripdir ..."
    makemkvcon mkv "$disc" all "$ripdir" --minlength=1200 --robot --progress \
      || err "MakeMKV rip failed"

    for f in "$ripdir"/*.mkv(N); do
      [[ -e "$f" ]] || continue
      json="$(probe_json "$f")"
      # Pick generic template for DVDs (MPEG-2 interlaced)
      vpy="$(make_vpy "$SCRIPT_DIR/Interlaced_Generic.vpy" "$f")"
      note ">> [interlaced_generic] $f"
      af="$(pick_audio_filter "$json")"
      base="${f:t:r}"
      out="$outdir/${base}_yt.mp4"
      vspipe --threads "$VS_THREADS" -c y4m "$vpy" - | encode_to_mp4 - "$f" "$out" "$af" \
        || err "ffmpeg failed for $f"
    done
    ;;

  file)
    [[ $# -eq 2 ]] || err "file mode: input_file export_dir"
    in="$(_abspath "$1")"; outdir="$(_abspath "$2")"
    [[ -e "$in" ]] || err "Input not found: $in"
    mkdir -p "$outdir"

    json="$(probe_json "$in")"
    codec="$(echo "$json" | python3 - <<'PY'
import sys,json
d=json.load(sys.stdin)
for s in d.get("streams",[]):
    if s.get("codec_type")=="video":
        print(s.get("codec_name",""))
        break
PY
)"
    # Choose template: DV (411) vs generic
    if [[ "$codec" = "dvvideo" ]]; then
      tmpl="$SCRIPT_DIR/DVTapes_411.vpy"
      tag="dv_411"
    else
      tmpl="$SCRIPT_DIR/Interlaced_Generic.vpy"
      tag="interlaced_generic"
    fi

    vpy="$(make_vpy "$tmpl" "$in")"
    note ">> [$tag] $in"
    af="$(pick_audio_filter "$json")"
    base="${in:t:r}"
    out="$outdir/${base}_yt.mp4"

    vspipe --threads "$VS_THREADS" -c y4m "$vpy" - | encode_to_mp4 - "$in" "$out" "$af" \
      || err "ffmpeg failed"
    ;;

  *)
    err "Unknown mode: $mode"
    ;;
esac

note "✔ Done."

