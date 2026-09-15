# VHS and grain GPU probe

Run `Tools/StyleEffectProbe/validate.sh` on an Apple silicon Mac with Metal access.
It compiles the production Metal source, compares output against the frozen
pre-optimization kernels, and measures warmed 4K GPU command durations.
No phone, camera, account, or stream is needed. It is a manual GPU probe, not a
simulator CI test or an end-to-end capture benchmark.

## Output checks

The probe checks grain, VHS, and their combination at strengths -1, 0, 0.5, and 1,
across animation frames 0–599, 4:2:0/4:2:2 chroma, 4K, and dimensions that leave
partial threadgroups. Grain is compared directly to the original arithmetic.
The maximum allowed difference is one 10-bit code step (64 underlying R16Unorm
codes); after restoring the original grain arithmetic, the measured maximum on
the M1 Pro was zero. These raw GPU comparisons do not assess appearance after
video encoding.

The original VHS kernel read and wrote displaced neighbours simultaneously and
had multiple threads write each chroma pixel. Its output was therefore dependent
on GPU execution order. The *comparison* reference gives that original arithmetic
immutable source pixels, one chroma owner, and signed offsets, as documented in
`main.swift`. It checks the intended filter, not equality with the old race.
The unchanged original kernel is retained separately for *timing*.

## Retained changes

Grain retains its original simplex corner calculations and coordinate arithmetic
to preserve its appearance, including after encoding. There is no additional
grain pass, buffer, or texture.

VHS skips distortion/noise arithmetic outside its top 5% zone and performs
chroma work once per chroma pixel. It reads an immutable chroma snapshot and a
snapshot of only the top 5% of luma; other luma pixels remain safe in place.
These reusable GPU textures take about 8.7 MiB at 4K 4:2:0 and are released when
another style is selected. Copies preserve Y/CbCr bits without color conversion.
A texture barrier orders style output before the next effect/overlay dispatch.

## Timing interpretation

Each command includes fixture reset copies; optimized VHS also includes its
required source copies. Runs alternate old/new order, discard 20 warm-up rounds,
and report the median of 44 further samples. Smaller grain threadgroups are also
reported for comparison; production keeps its existing group sizes.

M1 Pro, 3840×2160, 15 September 2026:

| Filter | Original | Optimized | GPU time reduction |
|---|---:|---:|---:|
| VHS | 1.950 ms | 1.962 ms | -0.6% (essentially unchanged) |

This is not an iPhone frame-rate or battery-life prediction. Camera processing,
encoding, overlays, display, thermal conditions, and memory layout also matter.
VHS's arithmetic savings mostly pay for making its sampling deterministic.
