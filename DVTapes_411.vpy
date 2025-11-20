# DVTapes_411.vpy — NTSC DV 4:1:1 to YUV422P16 + QTGMC (NNEDI3-only)
import vapoursynth as vs
core = vs.core

# DV source (e.g., .avi from WinDV, or a DV stream wrapped to .avi)
src = core.ffms2.Source("INPUT_DV.avi")  # replaced by wrapper

# DV 4:1:1 -> planar 4:2:2 16-bit; Rec.601 SD, limited, left chroma
yuv = core.resize.Spline36(
    src, format=vs.YUV422P16,
    matrix_in_s="470bg", matrix_s="470bg",
    range_in_s="limited", range_s="limited",
    chromaloc_in_s="left", chromaloc_s="left",
)

# QTGMC (NNEDI3 for both luma/chroma)
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

