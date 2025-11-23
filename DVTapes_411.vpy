# DVTapes_411.vpy — NTSC DV (YUV411P8) → YUV422P16 → QTGMC (NNEDI3 only)
# Pass the input path via env var VS_SRC to avoid sed/quoting headaches.

import os
import vapoursynth as vs
core = vs.core

# ---- Tuning knobs (env-driven, sane defaults) --------------------------------
# Field order: set VS_TFF=true|false to override (default True for DV)
tff = os.environ.get("VS_TFF", "true").lower() in ("1", "true", "yes", "on")

# Threads: VS_THREADS=<int>. Default = max(2, hw_threads-1)
try:
    _hw = os.cpu_count() or 4
    _def_threads = max(2, _hw - 1)
    core.num_threads = int(os.environ.get("VS_THREADS", str(_def_threads)))
except Exception:
    pass  # if assignment not supported, ignore

# Source path (REQUIRED): set VS_SRC="/path/to/file"
src_path = os.environ.get("VS_SRC", "INPUT_DV.avi")

# ---- Source (DV AVI; YUV411P8) ----------------------------------------------
src = core.ffms2.Source(src_path)

# ---- DV 4:1:1 → planar YUV 4:2:2 16-bit, Rec.601 SD (limited, left chroma) ---
yuv = core.resize.Spline36(
    src, format=vs.YUV422P16,
    matrix_in_s="470bg", matrix_s="470bg",
    range_in_s="limited", range_s="limited",
    chromaloc_in_s="left", chromaloc_s="left",
)

# ---- Provide a harmless stub so havsfunc can “see” eedi3m even if not installed
class _FakeEEDI3m:
    def EEDI3(self, *_, **__):
        raise RuntimeError("EEDI3m was called unexpectedly. Script is configured for NNEDI3.")

class _CoreProxy:
    def __getattr__(self, name):
        if name == "eedi3m":
            return _FakeEEDI3m()
        return getattr(vs.core, name)

import havsfunc as haf
haf.core = _CoreProxy()  # ensure any eedi3m access won’t crash

# ---- QTGMC (force NNEDI3 for luma & chroma) ----------------------------------
out = haf.QTGMC(
    yuv,
    Preset="Fast",
    TFF=tff,
    FPSDivisor=1,
    EdiMode="NNEDI3",
    ChromaEdi="NNEDI3",
)

out.set_output()

