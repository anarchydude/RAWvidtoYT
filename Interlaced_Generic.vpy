# Interlaced_Generic.vpy — generic interlaced sources → QTGMC (NNEDI3 only)
# Pass the input path via env var VS_SRC; matrix auto-picks 601 for SD, 709 for HD.

import os
import vapoursynth as vs
core = vs.core

# ---- Tuning knobs -------------------------------------------------------------
tff = os.environ.get("VS_TFF", "true").lower() in ("1", "true", "yes", "on")
try:
    _hw = os.cpu_count() or 4
    _def_threads = max(2, _hw - 1)
    core.num_threads = int(os.environ.get("VS_THREADS", str(_def_threads)))
except Exception:
    pass

src_path = os.environ.get("VS_SRC", "INPUT_FILE")

# ---- Source -------------------------------------------------------------------
src = core.ffms2.Source(src_path)

# Choose SD Rec.601 vs HD Rec.709 by resolution
matrix = "470bg" if (src.width <= 720 and src.height <= 576) else "709"

# If RGB or 4:1:1, convert explicitly; else promote to 16-bit 4:2:2
fmt = src.format
if (fmt.color_family != vs.YUV) or (fmt.subsampling_w == 2 and fmt.subsampling_h == 0):
    yuv = core.resize.Spline36(
        src, format=vs.YUV422P16,
        matrix_in_s=matrix, matrix_s=matrix,
        range_in_s="limited", range_s="limited",
        chromaloc_in_s="left", chromaloc_s="left",
    )
else:
    yuv = core.resize.Spline36(
        src, format=vs.YUV422P16,
        matrix_s=matrix, range_s="limited", chromaloc_s="left"
    )

# ---- Harmless eedi3m stub (see DV template) -----------------------------------
class _FakeEEDI3m:
    def EEDI3(self, *_, **__):
        raise RuntimeError("EEDI3m was called unexpectedly. Script is configured for NNEDI3.")

class _CoreProxy:
    def __getattr__(self, name):
        if name == "eedi3m":
            return _FakeEEDI3m()
        return getattr(vs.core, name)

import havsfunc as haf
haf.core = _CoreProxy()

# ---- QTGMC (NNEDI3 only) ------------------------------------------------------
out = haf.QTGMC(
    yuv,
    Preset="Fast",
    TFF=tff,
    FPSDivisor=1,
    EdiMode="NNEDI3",
    ChromaEdi="NNEDI3",
)

out.set_output()

