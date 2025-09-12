# Installing QTGMC via VapourSynth on macOS

## Prereqs

``` 
brew update
brew install vapoursynth ffmpeg meson ninja pkg-config git zimg p7zip 
```

vapoursynth: core runtime + vspipe
ffmpeg: output encoding
meson/ninja/pkg-config/git/zimg/p7zip: build tools & deps for a couple of plugins

## Install VapourSynth plugins & helper scripts

We’ll use a mix of vsrepo (for many plugins) and source builds for the two that matter on macOS/aarch64

``` 
# one-shot alias to a known-good vsrepo script location
alias vsrepo='python3 ~/.local/share/vsrepo/vsrepo.py'

# make sure the definitions are current
python3 ~/.local/share/vsrepo/vsrepo.py update

# install the essentials used by QTGMC/havsfunc
python3 ~/.local/share/vsrepo/vsrepo.py install havsfunc mvsfunc mvtools fmtconv rgvs ffms2 nnedi3_resample dfttest hqdn3d addgrain sangnom fft3dfilter
```
Why:

havsfunc provides QTGMC.
mvtools, fmtconv, rgvs (RemoveGrain), dfttest, hqdn3d, etc. are called by QTGMC paths.
ffms2 is the robust source filter we’ll use.
vsrepo installs plugin binaries to ~/.local/lib/vapoursynth and Python scripts to ~/Library/Python/<pyver>/lib/python/site-packages.

Create/refresh user autoload symlinks (safe to re-run):

```
mkdir -p ~/Library/Application\ Support/VapourSynth/plugins
ln -sf ~/.local/lib/vapoursynth/*.dylib ~/Library/Application\ Support/VapourSynth/plugins/
xattr -dr com.apple.quarantine ~/Library/Application\ Support/VapourSynth/plugins
```

### Build + install miscfilters (provides SCDetect used inside havsfunc)

```
git clone https://github.com/vapoursynth/vs-miscfilters-obsolete ~/.local/src/vs-miscfilters
cd ~/.local/src/vs-miscfilters
meson setup build --buildtype=release --prefix="$HOME/.local"
meson compile -C build
meson install -C build

# ensure autoload (user dir)
ln -sf ~/.local/lib/vapoursynth/libmiscfilters.dylib \
      ~/Library/Application\ Support/VapourSynth/plugins/libmiscfilters.dylib
```

### Build + install znedi3 (preferred NNEDI3 implementation; fast & works on Apple Silicon)

```
# grab repo WITH submodules
git clone --recursive https://github.com/sekrit-twc/znedi3 ~/.local/src/znedi3
cd ~/.local/src/znedi3

# build with Makefile (not Meson)
make

# install system-wide (autoload dir for Homebrew’s VapourSynth)
sudo mkdir -p /opt/homebrew/lib/vapoursynth
sudo cp ~/.local/src/znedi3/vsznedi3.so /opt/homebrew/lib/vapoursynth/libznedi3.dylib
sudo cp ~/.local/src/znedi3/nnedi3_weights.bin /opt/homebrew/lib/vapoursynth/nnedi3_weights.bin
sudo xattr -dr com.apple.quarantine /opt/homebrew/lib/vapoursynth/libznedi3.dylib /opt/homebrew/lib/vapoursynth/nnedi3_weights.bin
```
### Verify plugins are visible

Copy code and paste into command line

```
python3 - <<'PY'
import vapoursynth as vs
c = vs.core
print("VS:", c.version())
print("ffms2:", hasattr(c,"ffms2"))
print("misc :", hasattr(c,"misc"))
print("mv   :", hasattr(c,"mv"))
print("znedi3:", hasattr(c,"znedi3"))
PY
```
All should print True (except misc if you intentionally skipped it; QTGMC uses it for scenechange detection, so recommended).

## VapourSynth scripts

### For NTSC DV / YUV411P8 rips — e.g., WinDV captures

Converts DV 4:1:1 to YUV422P16 (Rec.601 SD, limited range, left chroma siting) and deinterlaces via QTGMC. Includes a tiny shim so havsfunc never hard-requires EEDI3m.

```
# DVTapes_411.vpy
import vapoursynth as vs
core = vs.core

# --- Source (DV AVI; YUV411P8) ---
src = core.ffms2.Source("INPUT_DV.avi")  # <-- set your file here or pass via templating

# --- DV 4:1:1 -> planar YUV for MVTools/QTGMC (Rec.601 SD, limited, left chroma siting) ---
yuv = core.resize.Spline36(
    src, format=vs.YUV422P16,
    matrix_in_s="470bg", matrix_s="470bg",
    range_in_s="limited", range_s="limited",
    chromaloc_in_s="left", chromaloc_s="left",
)

# --- shim so havsfunc can "see" eedi3m without actually using it ---
class _FakeEEDI3m:
    def EEDI3(self, *args, **kwargs):
        raise RuntimeError("EEDI3m path was called unexpectedly. QTGMC is configured to use NNEDI3.")

class _CoreProxy:
    def __getattr__(self, name):
        if name == "eedi3m":
            return _FakeEEDI3m()
        return getattr(vs.core, name)

# --- QTGMC using NNEDI3 (luma & chroma) ---
import havsfunc as haf
haf.core = _CoreProxy()
out = haf.QTGMC(
    yuv,
    Preset="Fast",
    TFF=True,          # flip to False if motion looks wrong
    FPSDivisor=1,
    EdiMode="NNEDI3",
    ChromaEdi="NNEDI3",
)
out.set_output()
```

### For unknown/interlaced sources with no extension, or non-DV

Attempts to pick the right matrix from resolution, converts to YUV422P16, and runs QTGMC. If your “raw” is actually elementary video or truly raw YUV, see Section 4 first to wrap/remux it so FFMS2 can open it.

```
# Interlaced_Generic.vpy
import vapoursynth as vs
core = vs.core

src = core.ffms2.Source("INPUT_FILE")  # <-- set your file here

# Choose SD Rec.601 vs HD Rec.709 based on resolution
matrix = "470bg" if (src.width <= 720 and src.height <= 576) else "709"

# If the source is RGB or YUV411, convert; otherwise promote to 16-bit 422
fmt = src.format
if (fmt.color_family != vs.YUV) or (fmt.subsampling_w == 2 and fmt.subsampling_h == 0):  # RGB or 411
    yuv = core.resize.Spline36(
        src, format=vs.YUV422P16,
        matrix_in_s=matrix, matrix_s=matrix,
        range_in_s="limited", range_s="limited",
        chromaloc_in_s="left", chromaloc_s="left",
    )
else:
    yuv = core.resize.Spline36(src, format=vs.YUV422P16, matrix_s=matrix, range_s="limited", chromaloc_s="left")

# QTGMC (force NNEDI3 to avoid EEDI3m)
import havsfunc as haf
out = haf.QTGMC(
    yuv,
    Preset="Fast",
    TFF=True,          # flip to False if motion looks wrong
    FPSDivisor=1,
    EdiMode="NNEDI3",
    ChromaEdi="NNEDI3",
)
out.set_output()
```
## Running the commands

```
# for DV rips (DVTapes_411.vpy)
vspipe -c y4m DVTapes_411.vpy - | ffmpeg -f yuv4mpegpipe -i - -i INPUT_DV.avi \
  -map 0:v:0 -map 1:a:0 \
  -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le \
  -c:a pcm_s16le -shortest out_prores_with_audio.mov

# for generic sources (Interlaced_Generic.vpy)
vspipe -c y4m Interlaced_Generic.vpy - | ffmpeg -f yuv4mpegpipe -i - -i INPUT_FILE \
  -map 0:v:0 -map 1:a:0 \
  -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le \
  -c:a pcm_s16le -shortest out_prores_with_audio.mov
```

## “Raw files with no extension”: Identify & Prep

First, figure out what they actually are:

```
# Quick, useful probes
file INPUT
ffprobe -hide_banner -v error -show_format -show_streams INPUT
mediainfo INPUT  # (brew install mediainfo)
```
Common cases & fixes:

It’s a valid container/stream but missing extension → just rename to .avi, .mov, .mkv, etc. and proceed.

Elementary MPEG-2/H.264/H.265 stream (no container): remux into MKV so FFMS2 can open it:
```
# example for mpeg2video
ffmpeg -f mpegvideo -i INPUT -c copy out.mkv
```
Raw DV (elementary DV stream): wrap to AVI:
`ffmpeg -f dv -i INPUT -c copy out.avi`
Truly raw YUV (e.g., 422p10le with known WxH): either rename with a .yuv recipe or ingest via ffmpeg to a container first:
```
# example: 720x576 422p10le
ffmpeg -f rawvideo -pix_fmt yuv422p10le -s 720x576 -i INPUT -c:v ffv1 -level 3 -pix_fmt yuv422p10le out.mkv
```
Then run Interlaced_Generic.vpy on out.mkv.

Once wrapped/remuxed, use Interlaced_Generic.vpy and the standard vspipe | ffmpeg command in Section 3.

## When your vapoursyth script is perfect: One-shot command to upscale to 4K for YouTube (forces VP9 on ingest)

If you want to go straight from VapourSynth to a 4K uploadable file:

Software encoding (H.264)
```
vspipe -c y4m Interlaced_Generic.vpy - | \
ffmpeg -f yuv4mpegpipe -i - \
  -vf "scale=3840:2160:flags=bicubic,format=yuv420p" \
  -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a aac -b:a 192k \
  -an out_4k_youtube.mp4
```
Hardware encoding (Videotoolbox)
```
vspipe -c y4m Interlaced_Generic.vpy - | \
ffmpeg -f yuv4mpegpipe -i - \
  -vf "scale=3840:2160:flags=bicubic,format=yuv420p" \
  -c:v h264_videotoolbox -b:v 40M -maxrate 50M -bufsize 80M \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a aac -b:a 192k \
  -an out_4k_youtube_hw.mp4
```

## Doing bulk folder runs

Process a whole folder of DV AVIs for example:

```
#!/usr/bin/env zsh
set -e
for f in *.avi; do
  base="${f:r}"
  sed "s|INPUT_DV.avi|$f|g" DVTapes_411.vpy > /tmp/_dv.vpy
  vspipe -c y4m /tmp/_dv.vpy - | ffmpeg -hide_banner -f yuv4mpegpipe -i - -i "$f" \
    -map 0:v:0 -map 1:a:0 \
    -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le \
    -c:a pcm_s16le -shortest "${base}_prores.mov"
done
```

## Cleanup

Remove source trees/build artifacts if you're done rebuilding:

```
# znedi3
[ -d ~/.local/src/znedi3 ] && { make -C ~/.local/src/znedi3 clean || true; rm -rf ~/.local/src/znedi3; }

# miscfilters
[ -d ~/.local/src/vs-miscfilters/build ] && { ninja -C ~/.local/src/vs-miscfilters/build clean || true; }
rm -rf ~/.local/src/vs-miscfilters

# pip cache (optional)
python3 -m pip cache purge

# homebrew housekeeping
brew cleanup
brew autoremove
```
Don’t delete:
/opt/homebrew/lib/vapoursynth/libznedi3.dylib and /opt/homebrew/lib/vapoursynth/nnedi3_weights.bin (autoloaded znedi3), and the plugin .dylibs you rely on in ~/Library/Application Support/VapourSynth/plugins/.

## Troubleshooting

No attribute with the name ffms2/mv/misc/znedi3 → the plugin didn’t autoload. Either put its .dylib into /opt/homebrew/lib/vapoursynth or user dir ~/Library/Application Support/VapourSynth/plugins/, then xattr -dr com.apple.quarantine <file>.

Colorspace/“no path between colorspaces” → ensure you convert 411/ RGB → planar YUV (422/444) and specify the correct SD/HD matrix and range (see scripts).

Judder/wrong field order → flip TFF=True ↔ False in the script.

FFmpeg Header too large after vspipe → the script threw an error; fix the stack trace printed above that line.
