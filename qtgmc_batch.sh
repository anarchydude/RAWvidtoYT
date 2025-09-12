#!/usr/bin/env zsh
# QTGMC batcher for single file / directory / DVD rips (MakeMKV)
# Requires: vapoursynth, vspipe, ffmpeg, ffprobe (+ optional makemkvcon)

# Re-exec under zsh if someone invoked via sh/bash
if [[ -z ${ZSH_VERSION-} ]]; then exec zsh "$0" "$@"; fi

# shell safety
set -e
set -u
set -o pipefail 2>/dev/null || true
setopt extended_glob

# -------------------------
# Defaults (override with env)
# -------------------------
MODE=${MODE:-auto}              # auto|dv|generic
VIDEO_MODE=${VIDEO_MODE:-yt}    # yt|prores
UPSCALE=${UPSCALE:-2160}        # 2160|1080|none (yt mode only)
PAD_16_9=${PAD_16_9:-0}         # 1 = pillarbox to 3840x2160 when UPSCALE=2160
ENCODER=${ENCODER:-vtb}        # x264|vtb
OUTDIR=${OUTDIR:-./_exports}
PRESET=${PRESET:-Fast}          # QTGMC preset
KEEP_TMP=${KEEP_TMP:-0}         # 1 to keep generated .vpy
KEEP_FFINDEX=${KEEP_FFINDEX:-0} # 1 to keep ffms2 .ffindex files
MAKEMKVCON=${MAKEMKVCON:-/Applications/MakeMKV.app/Contents/MacOS/makemkvcon}
CLEAN_RIP=1                # delete ripout even if you supplied a custom path

die(){ print -r -- "Error: $*" >&2; exit 1; }
need(){ whence -p "$1" >/dev/null || die "Missing dependency: $1"; }

need vspipe
need ffmpeg
need ffprobe

# locate templates (next to this script)
here=${0:A:h}
tmpl_dv="$here/DVTapes_411.vpy.tmpl"
tmpl_gen="$here/Interlaced_Generic.vpy.tmpl"
[[ -f $tmpl_dv && -f $tmpl_gen ]] || die "Missing template .vpy files beside script."

# ---------- ffprobe helpers ----------
probe_field_order(){ ffprobe -v error -select_streams v:0 -show_entries stream=field_order -of default=nw=1:nk=1 "$1" 2>/dev/null || true }
probe_pix_fmt(){    ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt     -of default=nw=1:nk=1 "$1" 2>/dev/null || true }
probe_codec(){      ffprobe -v error -select_streams v:0 -show_entries stream=codec_name  -of default=nw=1:nk=1 "$1" 2>/dev/null || true }
probe_dim(){        ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$1" 2>/dev/null || true }

infer_tff(){ # map ffprobe field_order -> True/False
  local fo="$1" def="${2:-True}"
  case "$fo" in
    tt|tb) print -r -- "True"  ;;
    bb|bt) print -r -- "False" ;;
    *)     print -r -- "$def"  ;;
  esac
}

select_template_and_tff(){ # echo "tmpl|tff|chosen|pix|codec|fo|dims"
  local in="$1"
  local pix="$(probe_pix_fmt "$in" | tr '[:upper:]' '[:lower:]')"
  local codec="$(probe_codec "$in" | tr '[:upper:]' '[:lower:]')"
  local fo="$(probe_field_order "$in")"
  local dims="$(probe_dim "$in")"
  local tmpl tff chosen
  if [[ "$MODE" == "dv" || "$pix" == "yuv411p" || "$codec" == "dvvideo" ]]; then
    tff="$(infer_tff "$fo" "False")"; tmpl="$tmpl_dv";  chosen="DV"
  else
    tff="$(infer_tff "$fo" "True")";  tmpl="$tmpl_gen"; chosen="GENERIC"
  fi
  print -r -- "$tmpl|$tff|$chosen|$pix|$codec|$fo|$dims"
}

make_vpy(){ # fill __INPUT__/__TFF__/__PRESET__
  local in="$1" out="$2" tmpl="$3" tff="$4"
  # escape & and \ for sed replacement
  local esc_in; esc_in="$(printf '%s' "$in" | sed 's/[&\\]/\\&/g')"
  sed -e "s|__INPUT__|$esc_in|g" \
      -e "s|__TFF__|$tff|g" \
      -e "s|__PRESET__|$PRESET|g" "$tmpl" > "$out"
}

cleanup_indexes(){
  local in="$1"
  [[ "$KEEP_FFINDEX" == "1" ]] && return 0
  local idx="${in}.ffindex"
  [[ -f "$idx" ]] && rm -f -- "$idx"
}

process_one(){
  local in="$1"
  [[ -f "$in" ]] || { print -r -- "Skip (not a file): $in"; return; }

  local meta tmpl tff chosen pix codec fo dims
  meta="$(select_template_and_tff "$in")"
  IFS="|" read -r tmpl tff chosen pix codec fo dims <<<"$meta"

  local base="${in:t:r}"
  local tmpvpy; tmpvpy="$(mktemp -t qtgmc_XXXXXX.vpy)"
  make_vpy "$in" "$tmpvpy" "$tmpl" "$tff"

  print -r -- ">> [$chosen] $in  (pix=$pix, codec=$codec, field_order=$fo, dims=$dims, TFF=$tff)"
  mkdir -p -- "$OUTDIR"

  # Square pixels first, then scale by height, optional pillarbox, then 420
  local vfilter="scale=round(iw*sar/2)*2:ih,setsar=1"
  if [[ "$VIDEO_MODE" == "yt" && "$UPSCALE" != "none" ]]; then
    vfilter+=",scale=-2:${UPSCALE}:flags=bicubic"
    if [[ "$PAD_16_9" == "1" && "$UPSCALE" == "2160" ]]; then
      vfilter+=",pad=3840:2160:(ow-iw)/2:(oh-ih)/2"
    fi
  fi
  vfilter+=",format=yuv420p"

  local out
  case "$VIDEO_MODE" in
    prores)
      out="$OUTDIR/${base}_prores.mov"
      vspipe -c y4m "$tmpvpy" - | ffmpeg -hide_banner -y \
        -f yuv4mpegpipe -i - -i "$in" \
        -map 0:v:0 -map 1:a:0 \
        -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le \
        -c:a pcm_s16le -shortest "$out"
      ;;
    yt)
      out="$OUTDIR/${base}_yt.mp4"
      if [[ "$ENCODER" == "vtb" ]]; then
        vspipe -c y4m "$tmpvpy" - | ffmpeg -hide_banner -y \
          -f yuv4mpegpipe -i - -i "$in" \
          -map 0:v:0 -map 1:a:0 \
          -filter:v "$vfilter" \
          -c:v h264_videotoolbox -b:v 40M -maxrate 50M -bufsize 80M \
          -color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv \
          -c:a aac -b:a 192k -movflags +faststart -shortest "$out"
      else
        vspipe -c y4m "$tmpvpy" - | ffmpeg -hide_banner -y \
          -f yuv4mpegpipe -i - -i "$in" \
          -map 0:v:0 -map 1:a:0 \
          -filter:v "$vfilter" \
          -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p \
          -color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv \
          -c:a aac -b:a 192k -movflags +faststart -shortest "$out"
      fi
      ;;
    *) die "Unknown VIDEO_MODE: $VIDEO_MODE" ;;
  esac

  # tidy
  [[ "$KEEP_TMP" == "1" ]] || rm -f -- "$tmpvpy"
  cleanup_indexes "$in"
  print -r -- "   -> $out"
}

process_dir(){
  local d="$1"
  setopt null_glob
  for f in "$d"/*.(mkv|mpg|vob|avi|mov|mp4)(N); do
    process_one "$f"
  done
  unsetopt null_glob
}

rip_dvd_and_process(){
  # dvd [source] [ripout] [outdir]
  local source="${1:-disc:0}"
  local ripout_arg="${2:-}"
  local outdir_override="${3:-}"

  [[ -n "$outdir_override" ]] && OUTDIR="$outdir_override"
  [[ -x "$MAKEMKVCON" ]] || die "makemkvcon not found at '$MAKEMKVCON' (set MAKEMKVCON=...)"

  # Decide where to rip:
  # - If caller gave a ripout path => use it; delete only if CLEAN_RIP=1
  # - If not given => create a unique temp dir and auto-delete after
  local ripout cleanup_ripout=0
  if [[ -n "$ripout_arg" ]]; then
    ripout="$ripout_arg"
    [[ "${CLEAN_RIP:-auto}" == "1" ]] && cleanup_ripout=1
    mkdir -p -- "$ripout"
  else
    ripout="$(mktemp -d -t qtgmc_rip_XXXXXX)"
    cleanup_ripout=1
  fi

  print -r -- ">> Ripping all titles ≥20 min to $ripout ..."

  # Build MakeMKV source spec; switch to disc:N if VIDEO_TS path is on a read-only optical volume
  local srcspec=""
  if [[ "$source" == disc:* ]]; then
    srcspec="$source"
  elif [[ -f "$source" && "${source:e:l}" == "iso" ]]; then
    srcspec="iso:$source"
  elif [[ -d "$source" && ( -f "$source/VIDEO_TS.IFO" || "$source" == *"VIDEO_TS"* ) ]]; then
    if [[ ! -w "$source" ]]; then
      local discnum="${DISC:-0}"
      print -r -- ">> Detected read-only optical volume; switching to disc:$discnum"
      srcspec="disc:$discnum"
    else
      srcspec="file:$source"
    fi
  else
    die "Unrecognized DVD source: $source (use disc:0, /path/to/VIDEO_TS, or /path/to/disc.iso)"
  fi

  # Non-interactive ripping (no prompts), keep titles ≥ 20 minutes
  "$MAKEMKVCON" --robot --minlength=1200 mkv "$srcspec" all "$ripout"

  print -r -- ">> Processing ripped MKVs from $ripout ..."
  process_dir "$ripout"

  if (( cleanup_ripout )); then
    print -r -- ">> Cleaning temp rip dir $ripout"
    rm -rf -- "$ripout"
  else
    print -r -- ">> Keeping rip dir $ripout (set CLEAN_RIP=1 to auto-delete)"
  fi
}

usage(){
cat <<'EOF'
Usage:
  qtgmc_batch.zsh file <input>                          # process single file
  qtgmc_batch.zsh dir  <folder>                         # process all mkv/mpg/vob/avi/mov/mp4 in folder
    qtgmc_batch.zsh dvd [source] [ripout] [outdir]        # MakeMKV -> MKVs -> process
    source : disc:0 (default), /path/to/VIDEO_TS, or /path/to/disc.iso
    ripout : temp dir auto-created & auto-deleted if omitted; if given, kept unless CLEAN_RIP=1
    outdir : exports folder (overrides OUTDIR)

Env:
  MODE=auto|dv|generic
  VIDEO_MODE=yt|prores
  UPSCALE=2160|1080|none
  PAD_16_9=1
  ENCODER=x264|vtb
  OUTDIR=/path/to/exports
  PRESET=Fast|Medium|...
  KEEP_TMP=1                 # keep temp .vpy
  KEEP_FFINDEX=1             # keep ffms2 .ffindex
  MAKEMKVCON=/Applications/MakeMKV.app/Contents/MacOS/makemkvcon

Examples:
  ENCODER=vtb UPSCALE=2160 ./qtgmc_batch.zsh file "/Users/you/SC A1"
  PAD_16_9=1 ENCODER=x264   ./qtgmc_batch.zsh dir  "/Volumes/Rips"
  ./qtgmc_batch.zsh dvd "/Volumes/DVD Video Recording/VIDEO_TS" "/tmp/_dvd_rips" "$HOME/Documents/QTGMC/_exports"
  ./qtgmc_batch.zsh dvd disc:0 "/tmp/_dvd_rips" "$HOME/Documents/QTGMC/_exports"
EOF
}

cmd="${1:-}"
case "$cmd" in
  file) [[ $# -ge 2 ]] || { usage; exit 1; }; process_one "$2" ;;
  dir)  [[ $# -ge 2 ]] || { usage; exit 1; }; process_dir "$2" ;;
  dvd)  rip_dvd_and_process "${2:-disc:0}" "${3:-/tmp/_dvd_rips}" "${4:-}" ;;
  *)    usage; exit 1 ;;
esac

