#!/usr/bin/env sh
# qtgmc_batch.sh — POSIX sh, macOS/Linux
# Modes:
#   dvd  <disc_id|/dev/...> <rip_dir> <export_dir> [--min-minutes N] [--tff true|false] [--dual-mono|--mono-from-left|--mono-from-right]
#   file <input_file>       <export_dir>          [--tff true|false] [audio flags...]
#   dir  <input_dir>        <export_dir>          [--tff true|false] [audio flags...]
set -eu

# ---------- helpers ----------
die(){ printf >&2 "xx %s\n" "$*"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
abspath(){ python3 - "$1" <<'PY'
import os,sys; print(os.path.abspath(sys.argv[1]))
PY
}

# temp file (BSD/GNU mktemp)
: "${TMPDIR:=/tmp}"
mkvpy() { mktemp "${TMPDIR%/}/qtgmc_vpy.XXXXXXXX.vpy"; }

# threads: VS defaults to num CPU; allow override
: "${VS_THREADS:=$(python3 - <<'PY'
import os, multiprocessing as m
print(max(1, min(16, (m.cpu_count() or 1)-0)))  # a cautious default
PY
)}"

# optional audio flags → ffmpeg -af
audio_afilt=""
case "${1-}" in
  --help|-h|'') cat <<USAGE
Usage:
  $0 dvd  disc:0           /path/to/_dvd_rips  /path/to/_exports [--min-minutes 20] [--tff true|false] [--dual-mono|--mono-from-left|--mono-from-right]
  $0 file /path/to/input   /path/to/_exports   [--tff true|false] [audio flags...]
  $0 dir  /path/to/folder  /path/to/_exports   [--tff true|false] [audio flags...]

Env:
  VS_THREADS=N   (override VapourSynth worker threads)
USAGE
  exit 0;;
esac

# ---------- ffprobe-based sniff ----------
probe_json(){
  in="$1"
  ffprobe -hide_banner -v error -select_streams v:0 \
    -show_entries stream=pix_fmt,codec_name,width,height,field_order \
    -of json -- "$in"
}

val_from_json(){ python3 - "$1" "$2" <<'PY'
import sys,json
j=json.load(sys.stdin)
k=sys.argv[1]
def get(d, ks):
  for x in ks.split("."):
    if isinstance(d, list): d=d[0] if d else {}
    d=d.get(x,{})
  return d if d else None
v=get(j,k)
print(v if v is not None else "")
PY
}

# ---------- template runner ----------
# Requires DVTapes_411.vpy and Interlaced_Generic.vpy alongside this script or in CWD.
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
tmpl_dv="${script_dir}/DVTapes_411.vpy"
tmpl_gen="${script_dir}/Interlaced_Generic.vpy"
[ -f "$tmpl_dv" ]  || die "Missing template: $tmpl_dv"
[ -f "$tmpl_gen" ] || die "Missing template: $tmpl_gen"

make_vpy(){
  in="$1"; tag="$2"; tff="$3"
  vpy="$(mkvpy)" || die "mktemp failed"
  case "$tag" in
    DVTapes_411)
      # replace INPUT_DV.avi + TFF=X in DV template
      sed "s|INPUT_DV\.avi|$in|g; s|TFF=True|TFF=${tff}|g" "$tmpl_dv" > "$vpy"
      ;;
    Interlaced_Generic)
      sed "s|INPUT_FILE|$in|g; s|TFF=True|TFF=${tff}|g" "$tmpl_gen" > "$vpy"
      ;;
    *) die "unknown template tag: $tag" ;;
  esac
  printf %s "$vpy"
}

# audio helper flags
apply_audio_flag(){
  case "${1-}" in
    --dual-mono)        audio_afilt='-af pan=stereo|c0=0.5*c0+0.5*c1|c1=0.5*c0+0.5*c1' ;;
    --mono-from-left)   audio_afilt='-af pan=stereo|c0=c0|c1=c0' ;;
    --mono-from-right)  audio_afilt='-af pan=stereo|c0=c1|c1=c1' ;;
    *) ;;
  esac
}

# ---------- core processing ----------
process_one(){
  in="$1"; outdir="$2"; forcetff="${3-}"
  [ -f "$in" ] || die "Input file not found: $in"

  js="$(probe_json "$in")" || die "ffprobe failed on: $in"
  codec="$(printf %s "$js" | val_from_json 'streams.codec_name')"
  pix="$(  printf %s "$js" | val_from_json 'streams.pix_fmt')"
  w="$(    printf %s "$js" | val_from_json 'streams.width')"
  h="$(    printf %s "$js" | val_from_json 'streams.height')"

  # choose template & default TFF
  tag="Interlaced_Generic"; tff_default="True"
  [ "$codec" = "dvvideo" ] && tag="DVTapes_411" && tff_default="False"
  [ "$pix" = "yuv411p" ]   && tag="DVTapes_411" && tff_default="False"
  tff="${forcetff:-$tff_default}"

  base="$(basename -- "$in")"
  base="${base%.*}"
  out="$outdir/${base}_4k_hw.mp4"

  printf ">> [%s] %s  (pix=%s, codec=%s, TFF=%s, threads=%s)\n" "$tag" "$in" "${pix:-?}" "${codec:-?}" "$(printf %s "$tff" | tr 'A-Z' 'a-z')" "$VS_THREADS"

  vpy="$(make_vpy "$in" "$tag" "$tff")"
  trap 'rm -f "$vpy"' EXIT INT HUP TERM

  # build ffmpeg audio args
  aflags=""
  if [ -n "$audio_afilt" ]; then
    aflags="$audio_afilt"
  fi

  # run: VapourSynth → ffmpeg (vt hw encode + 4k upscale)
  vspipe -y -c y4m "$vpy" - 2>/dev/null | \
  ffmpeg -hide_banner -y -f yuv4mpegpipe -i - -i "$in" \
    -map 0:v:0 -map 1:a:0 \
    -vf "scale=3840:2160:flags=bicubic,format=yuv420p" \
    -c:v h264_videotoolbox -b:v 40M -maxrate 50M -bufsize 80M \
    -c:a aac -b:a 192k -shortest \
    $aflags \
    "$out" || die "ffmpeg failed"

  echo "✔ wrote: $out"
  rm -f "$vpy"
  trap - EXIT INT HUP TERM
}

process_dir(){
  indir="$1"; outdir="$2"; forcetff="${3-}"
  found=0
  # Process MKVs first (DVD rips), then common containers
  for f in "$indir"/*.mkv "$indir"/*.mov "$indir"/*.avi "$indir"/*.mp4 "$indir"/*.mpg "$indir"/*.m2v; do
    [ -f "$f" ] || continue
    found=1
    process_one "$f" "$outdir" "$forcetff"
  done
  [ "$found" -eq 1 ] || die "No media files found in: $indir"
}

# ---------- DVD ripping (MakeMKV) ----------
find_makemkvcon(){
  if have makemkvcon; then
    echo "makemkvcon"; return 0
  fi
  # macOS app bundle path
  if [ -x "/Applications/MakeMKV.app/Contents/MacOS/makemkvcon" ]; then
    echo "/Applications/MakeMKV.app/Contents/MacOS/makemkvcon"; return 0
  fi
  return 1
}

rip_dvd(){
  disc="$1"; ripdir="$2"; minmin="$3"
  mmc="$(find_makemkvcon)" || die "makemkvcon not found. Install MakeMKV and its CLI."
  mkdir -p "$ripdir"

  # MakeMKV expects seconds for minlength
  minsec=$(( ${minmin:-20} * 60 ))

  echo ">> Ripping all titles ≥${minmin:-20} min to $ripdir ..."
  # Common, quiet-ish invocation; progress on stdout, auto-accepts existing files by unique names.
  # If overwrite prompts happen in your setup, pre-clean the target or add a --force flag on your side.
  "$mmc" mkv "$disc" all "$ripdir" --minlength="$minsec" --progress=-stdout || die "MakeMKV rip failed"

  echo ">> Rip complete."
}

# ---------- parse & run ----------
mode="$1"; shift

# peel out optional flags (any mode)
force_tff=""
min_minutes=""
audio_flag=""
rest=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tff)
      [ $# -ge 2 ] || die "--tff requires true|false"
      force_tff="$2"; shift 2;;
    --min-minutes)
      [ $# -ge 2 ] || die "--min-minutes requires a number"
      min_minutes="$2"; shift 2;;
    --dual-mono|--mono-from-left|--mono-from-right)
      audio_flag="$1"; shift 1;;
    --) shift; break;;
    -*)
      die "Unknown flag: $1";;
    *)
      rest="$rest $1"; shift 1;;
  esac
done
# apply audio flag if set
[ -n "${audio_flag:-}" ] && apply_audio_flag "$audio_flag"

set -- $rest

case "$mode" in
  dvd)
    [ $# -ge 3 ] || die "dvd requires: <disc_id|/dev/...> <rip_dir> <export_dir> [flags]"
    disc="$1"; ripdir="$(abspath "$2")"; outdir="$(abspath "$3")"
    mkdir -p "$ripdir" "$outdir"
    rip_dvd "$disc" "$ripdir" "${min_minutes:-20}"
    process_dir "$ripdir" "$outdir" "$force_tff"
    ;;
  file)
    [ $# -ge 2 ] || die "file requires: <input_file> <export_dir> [flags]"
    in="$(abspath "$1")"; outdir="$(abspath "$2")"; mkdir -p "$outdir"
    process_one "$in" "$outdir" "$force_tff"
    ;;
  dir)
    [ $# -ge 2 ] || die "dir requires: <input_dir> <export_dir> [flags]"
    indir="$(abspath "$1")"; outdir="$(abspath "$2")"; mkdir -p "$outdir"
    process_dir "$indir" "$outdir" "$force_tff"
    ;;
  *)
    die "unknown mode: $mode"
    ;;
esac

