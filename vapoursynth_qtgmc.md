# Installing QTGMC via VapourSynth on macOS

This repo provides:
- `qtgmc_batch.zsh` — a wrapper that rips DVDs (MakeMKV) or processes files with VapourSynth+QTGMC and encodes to a YouTube-ready 4K MP4, **with explicit thread limits** so your Mac stays usable.
- `Interlaced_Generic.vpy` and `DVTapes_411.vpy` — NNEDI3-only QTGMC templates (no EEDI3m) that survived macOS 15 “Tahoe” updates.s

## Prereqs

Homebrew
MakeMKV/MakeMKV-CLI

### Install Vapoursynth and dependencies needed

```
brew update
brew install vapoursynth ffmpeg ffms2 meson ninja pkg-config zimg git
# ffms2 needs a VS symlink (Homebrew caveat):
sudo mkdir -p /opt/homebrew/lib/vapoursynth
test -e /opt/homebrew/lib/vapoursynth/libffms2.dylib || \
  (cd /opt/homebrew/lib/vapoursynth && sudo ln -s ../libffms2.dylib libffms2.dylib)
```

vapoursynth: core runtime + vspipe
ffmpeg: output encoding
meson/ninja/pkg-config/git/zimg/p7zip: build tools & deps for a couple of plugins

## Install VapourSynth plugins & build two to be Apple Silicon-Native

We’ll use a mix of vsrepo (for many plugins) and source builds for the two that matter on macOS/aarch64

``` 
# make sure the definitions are current
python3 ~/.local/share/vsrepo/vsrepo.py update || true

# install the essentials used by QTGMC/havsfunc
python3 ~/.local/share/vsrepo/vsrepo.py install \
  havsfunc mvsfunc mvtools fmtconv rgvs ffms2 nnedi3_resample dfttest hqdn3d addgrain sangnom fft3dfilter adjust
```
Why:

havsfunc provides QTGMC.
mvtools, fmtconv, rgvs (RemoveGrain), dfttest, hqdn3d, etc. are called by QTGMC paths.
ffms2 is the robust source filter we’ll use.
vsrepo installs plugin binaries to ~/.local/lib/vapoursynth and Python scripts to ~/Library/Python/<pyver>/lib/python/site-packages.

Note, that vsrepo may skip fmtconv and miscfilters binaries on Apple Silicon, so we have to build them.

### Build fmtconv

```
git clone https://github.com/EleonoreMizo/fmtconv ~/.local/src/fmtconv
cd ~/.local/src/fmtconv/build/unix
# ensure build deps are visible
export PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig:$PKG_CONFIG_PATH"
export CFLAGS="-I/opt/homebrew/include $CFLAGS"
export CXXFLAGS="-I/opt/homebrew/include $CXXFLAGS"
export LDFLAGS="-L/opt/homebrew/lib $LDFLAGS"

./autogen.sh
./configure --prefix="$HOME/.local"
make -j"$(sysctl -n hw.ncpu)"
make install

# Put into VS autoload (system-wide is most reliable on macOS)
sudo cp ~/.local/lib/libfmtconv.dylib /opt/homebrew/lib/vapoursynth/
sudo xattr -dr com.apple.quarantine /opt/homebrew/lib/vapoursynth/libfmtconv.dylib
```

### Build miscfilters (for SCDetect)

```
git clone https://github.com/vapoursynth/vs-miscfilters-obsolete ~/.local/src/vs-miscfilters
cd ~/.local/src/vs-miscfilters
meson setup build --buildtype=release --prefix="$HOME/.local"
meson compile -C build
meson install -C build

# Put into VS autoload
sudo cp ~/.local/lib/vapoursynth/libmiscfilters.dylib /opt/homebrew/lib/vapoursynth/
sudo xattr -dr com.apple.quarantine /opt/homebrew/lib/vapoursynth/libmiscfilters.dylib
```

### Optional but recommended: add znedi3 (fast NNEDI3 for Apple Silicon)

Homebrew’s vapoursynth-znedi3 isn’t universal everywhere; if needed, build from source:

```
git clone --recursive https://github.com/sekrit-twc/znedi3 ~/.local/src/znedi3
cd ~/.local/src/znedi3 && make
sudo cp vsznedi3.so /opt/homebrew/lib/vapoursynth/libznedi3.dylib
sudo cp nnedi3_weights.bin /opt/homebrew/lib/vapoursynth/nnedi3_weights.bin
sudo xattr -dr com.apple.quarantine /opt/homebrew/lib/vapoursynth/libznedi3.dylib /opt/homebrew/lib/vapoursynth/nnedi3_weights.bin
```

### Verify plugins are visible

```
python3 - <<'PY'
import vapoursynth as vs
c=vs.core
print("ffms2:", hasattr(c,"ffms2"))
print("fmtc :", hasattr(c,"fmtc"))
print("misc :", hasattr(c,"misc"))
print("znedi3:", hasattr(c,"znedi3"))
PY
```

All should print True except znedi3 if you didn’t install it (QTGMC still works, just slower).

## Usage

In the same folder (your “tooling” folder), keep:

qtgmc_batch.zsh ← the runner
Interlaced_Generic.vpy ← template for most interlaced sources
DVTapes_411.vpy ← template for DV (YUV411) camera captures

Then open Terminal in that directory, or cd to that directory.

### Process a DVD

This will: (a) rip titles ≥20 minutes with MakeMKV (adjustable in the script), then (b) deinterlace + upscale + encode.

```
# Syntax
./qtgmc_batch.zsh dvd disc:0 "{dvd rip path}" "{converted file destination}"

# Example
./qtgmc_batch.zsh dvd disc:0 "/Users/user/Movies/RAWvidtoYT/_dvd_rips" "/Users/user/Movies/RAWvidtoYT/_exports"
```

disc:0 = your first optical drive (try disc:1 if you have more than one).

Rips are saved to: /Users/jondurand/Documents/QTGMC/_dvd_rips
Finished MP4s land in: /Users/jondurand/Documents/QTGMC/_exports

### Process a single video file

For files you already have (e.g., .mkv, .avi, .mov). The script auto-detects DV vs non-DV video (since I do a lot of DV conversions) and picks the right template.

```
# Syntax
./qtgmc_batch.zsh file "{path to source file}" "{converted file destination}"

# Example
./qtgmc_batch.zsh file "/Users/user/Movies/B1_t00.mkv" "/Users/user/Movies/RAWvidtoYT/_exports"

```
You’ll get something like:
/Users/user/Movies/RAWvidtoYT/_exports/B1_t00_yt.mp4


### Make it not crush your Mac's CPU (optional)

Defaults are set to be modest, but you can set your own per-run:

```
VS_THREADS=4 FFMPEG_THREADS=4 FILTER_THREADS=2 \
  ./qtgmc_batch.zsh file "/Users/user/Movies/B1_t00.mkv" "/Users/user/Movies/RAWvidtoYT/_exports"

```
VS_THREADS → VapourSynth threads
FFMPEG_THREADS → encoder threads
FILTER_THREADS → FFmpeg filter threads

Good quiet-laptop starting point: 4/4/2.


### Fix lopsided / mono audio (optional)

Some captures are left-channel only or true mono. You can force a clean stereo output:

#### Force left → both:
```
FORCE_L_TO_R=1 ./qtgmc_batch.zsh file "/Users/jondurand/Documents/QTGMC/_dvd_rips/B1_t00.mkv" "/Users/jondurand/Documents/QTGMC/_exports"
```

#### Duplicate mono → stereo:
```
MONO_DUP=1 ./qtgmc_batch.zsh file "/Users/jondurand/Documents/QTGMC/_dvd_rips/B1_t00.mkv" "/Users/jondurand/Documents/QTGMC/_exports"
```
(The script already auto-fixes obvious mono; these switches are for edge cases.)


## What actually happens when you run it

### Mode choose

dvd → uses makemkvcon to rip long titles to /Users/jondurand/Documents/QTGMC/_dvd_rips.
file → uses your given source file.

### Template pick

If the source is DV (YUV411) → DVTapes_411.vpy.

Otherwise → Interlaced_Generic.vpy.

### VapourSynth (QTGMC)

The script fills a temp .vpy with the source path and runs:
```
vspipe -c y4m <template>.vpy -
```
This produces a Y4M video stream (deinterlaced, properly colorspaced, 16-bit internal, then to 8/10-bit at encode).

### FFmpeg encode

FFmpeg reads the Y4M stream from stdin, and the original file for audio. It upscales to 3840×2160 (bicubic), tags BT.709 color, and encodes with h264_videotoolbox (≈40 Mbps default). Audio is kept/converted to AAC 192k stereo, with optional fixes for mono/left-only.

Result: a 4K MP4 YouTube will quickly give a high-quality transcode for (usually VP9/AV1 after processing).

## Troubleshooting

### Quick “it didn’t work” checklist

Plugin missing (e.g., ffms2 / fmtc / misc / znedi3 shows False in a test)?
Make sure the .dylib plugins live in:
``` 
/opt/homebrew/lib/vapoursynth/
```
and clear quarantine
```
sudo xattr -dr com.apple.quarantine /opt/homebrew/lib/vapoursynth/*.dylib
```

### You see “Header too large” after vspipe?
That means the VapourSynth script failed; the Python error just above tells you which plugin/path/setting is wrong.

### Motion/judder looks wrong?
Open the template you used and flip:
```
TFF=True  # → False
```
### Homebrew’s ffms2 caveat (only once):
```
sudo mkdir -p /opt/homebrew/lib/vapoursynth
test -e /opt/homebrew/lib/vapoursynth/libffms2.dylib || \
  (cd /opt/homebrew/lib/vapoursynth && sudo ln -s ../libffms2.dylib libffms2.dylib)
```

## Power User Knobs (Optional)

Lower/raise bitrate (hardware H.264):

```
VT_BITRATE=30M VT_MAXRATE=40M VT_BUFSIZE=60M ./qtgmc_batch.zsh file "/path/in.mkv" "/Users/jondurand/Documents/QTGMC/_exports"
```
Prefer software x264 for archival? Swap the encoder block or pipe into your own ffmpeg line from vspipe. (Open a Git issue/PR and I’ll include a preset.)
