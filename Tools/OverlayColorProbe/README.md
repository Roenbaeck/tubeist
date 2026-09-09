# Overlay color validation without a phone

Run on a Mac with Metal and Xcode:

```sh
Tools/OverlayColorProbe/validate.sh
Tools/OverlayColorProbe/validate.sh /path/to/test-chart.jpeg /path/to/overlay.png
```

The probe compiles the production `ImprintArguments.swift` and `Kernels.metal`.
It renders sRGB sources to the same premultiplied HLG texture format as Tubeist,
then executes `imprint` against real, HLG-tagged Core Video pixel buffers.
Core Image's own HLG source-over and YCbCr renderer supplies an independent
reference. No camera, simulator, network access, or app installation is needed.
GPU access must be available; an empty Core Image render fails the probe.

It checks 214 patches per format across 10-bit 4:2:0 and 4:2:2, each in full
and video range: a grayscale ramp, primary colors, and deterministic colors
with alpha 0, 0.25, 0.5, 0.75, and 1. The background is colored to exercise
chroma blending. Every Y/Cb/Cr sample must match within one ten-bit code;
transparent overlays must preserve the background exactly. Output samples
must occupy the high ten bits of each 16-bit word.

Optional local images also check orientation and the entire luma plane against
the reference (maximum two codes, mean below 0.1 code). Their chroma edges are
not compared because Core Image resamples chroma while Tubeist's imprint kernel
samples one overlay texel per chroma sample. The patch tests cover chroma in
uniform regions.

This tests the conversion and HLG compositing stages, including the final
YCbCr buffers. It does not test WebKit capture, the production actor lifecycle,
encoding, browser transparency blending, or the physical display's reference
white and HDR presentation. In particular, passing these checks does not prove
that INPUT and OUTPUT look identical on an iPhone.
