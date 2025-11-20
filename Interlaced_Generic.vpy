# Interlaced_Generic.vpy — QTGMC (NNEDI3-only) for generic interlaced sources
import vapoursynth as vs
core = vs.core

# Replace by wrapper
src = core.ffms2.Source("INPUT_FILE")

# Decide SD vs HD matrix from resolution
matrix = "470bg" if (src.width <= 720 and src.height <= 576) else "709"

# Convert to planar 4:2:2 16-bit (and ensure left chroma siting, limited range)
fmt = src.format
if (fmt.color_family != vs.YUV) or (fmt.subsampling_w == 2 and fmt.subsampling_h == 0):  # RGB or 4:1:1
    yuv = core.resize.Spline36(
        src, format=vs.YUV422P16,
        matrix_in_s=matrix, matrix_s=matrix,
        range_in_s="limited", range_s="limited",
        chromaloc_in_s="left", chromaloc_s="left",
    )
else:
    yuv = core.resize.Spline36(
        src, format=vs.YUV422P16,
        matrix_s=matrix, range_s="limited",
        chromaloc_s="left"
    )

# QTGMC using NNEDI3 for luma & chroma; no EEDI3m dependency
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

