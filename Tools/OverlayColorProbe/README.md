# Overlay color validation without a phone

Run on a Mac with Metal and Xcode:

```sh
Tools/OverlayColorProbe/validate.sh
Tools/OverlayColorProbe/validate.sh /path/to/test-chart.jpeg /path/to/overlay.png
```

The probe compiles the production `ImprintArguments.swift` and `Kernels.metal`.
It renders sRGB sources to the same premultiplied HLG texture format as Tubeist,
then executes `imprint` against real, HLG-tagged Core Video pixel buffers.
No camera, simulator, network access, or app installation is needed. GPU access
must be available; an empty Core Image render fails the probe.

## Blending convention

Tubeist prioritizes the appearance of web overlays. Fractional-alpha source-over
is evaluated in **extended, nonlinear sRGB**, then encoded back into HLG.
This is intentionally different from physically linear-light compositing.

The shader unpremultiplies the overlay's HLG RGB and reconstructs the camera's
HLG RGB from its existing YCbCr samples. Both are transformed through the
BT.2100 reference HLG EOTF (1,000-nit peak, system gamma 1.2), the BT.2020-to-sRGB
matrix, and the sRGB transfer function, with SDR white anchored at 203 nits.
Standard source-over is applied once in that web compositing space; the inverse
mapping returns the result to HLG. Alpha has no gamma adjustment. See
[BT.2100, Table 5](https://www.itu.int/rec/R-REC-BT.2100-3-202502-I/en) and
[CSS Color 4](https://www.w3.org/TR/css-color-4/).

These calculations happen in floating-point shader temporaries. Negative and
above-white sRGB components remain unclipped, preserving HDR and wide-gamut
information through the calculation. There is no SDR intermediate image or
full-frame conversion. The camera buffer remains HLG/BT.2020 YCbCr, and the
phone's current display headroom never participates in the blend.

Opaque pixels bypass the transfer functions. Zero-alpha luma and entirely
uncovered chroma cells are not rewritten. One invocation owns each chroma cell,
averaging the chroma changes from its covered pixels before writing the shared
sample. Dispatch regions are aligned and coalesced to prevent races or
compositing overlapping regions twice. Shared chroma necessarily affects
neighboring pixels at overlay edges.

## Checks and reference

An independent, Double-precision CPU implementation of the HLG/sRGB transforms
and source-over provides the reference. It uses the quantized camera samples
and actual overlay texture, computes the full-resolution result, then reduces
chroma separately. This separates blending error from source conversion and
quantization. Core Image supplies test inputs; it is not the arithmetic oracle.
Its HLG-to-linear conversion differs from the BT.2100 reference equations for
colored samples on the tested Mac.

The probe checks 214 patches per format across 10-bit 4:2:0 and 4:2:2, each in
full and video range: a grayscale ramp, primary colors, and deterministic
colors with alpha 0, 0.25, 0.5, 0.75, and 1. Every Y/Cb/Cr sample must match
within one ten-bit code; transparent overlays must preserve the background
exactly. Output samples must occupy the high ten bits of each 16-bit word.

Patterned cases exercise varying camera luma and overlay alpha inside shared
chroma cells, odd bounding-box edges, overlap coalescing, and three identical
runs to detect nondeterministic in-place reads. A separate closed-form check
requires half-opacity black to halve the extended-sRGB code value at HLG levels
0.75, 0.875, and 1.0, including above-white values. Optional local images compare
both complete planes with the CPU reference (maximum one code, mean below
0.01 code).

This tests the arithmetic, dispatch regions, and resulting YCbCr buffers. It
does not test WebKit capture, the production actor lifecycle, encoding, or the
physical display. The separate modern scoreboard recording test showed less
than one RGB code of mean absolute difference from Mac WebKit across flat
translucent regions on five backgrounds. That is not a whole-image maximum
error or a guarantee that INPUT and OUTPUT are identical on every iPhone.
